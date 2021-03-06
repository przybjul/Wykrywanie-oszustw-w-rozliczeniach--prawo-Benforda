use ML;
go

drop procedure if exists [BenfordFraud].getFraudData
go
create procedure [BenfordFraud].getFraudData
as
begin
	select VendorNumber, VoucherNumber, CheckNumber, InvoiceNumber, InvoiceDate, PaymentDate, DueDate, InvoiceAmount
	  from [BenfordFraud].[Invoices];
end;
go

-- Generates the Digits and Frequency for each vendor
drop function if exists [BenfordFraud].VendorInvoiceDigits
go
create function [BenfordFraud].VendorInvoiceDigits (@VendorNumber varchar(10) = null)
returns table
as
return
	with f as (
		select VendorNumber
			 , InvoiceAmount
			 , round(case
					when InvoiceAmount >= 1000000000 then InvoiceAmount / 1000000000
					when InvoiceAmount >= 100000000 then InvoiceAmount / 100000000
					when InvoiceAmount >= 10000000 then InvoiceAmount / 10000000
					when InvoiceAmount >= 1000000 then InvoiceAmount / 1000000
					when InvoiceAmount >= 100000 then InvoiceAmount / 100000
					when InvoiceAmount >= 10000 then InvoiceAmount / 10000
					when InvoiceAmount >= 1000 then InvoiceAmount / 1000
					when InvoiceAmount >= 100 then InvoiceAmount / 100
					when InvoiceAmount >= 10 then InvoiceAmount / 10
					when InvoiceAmount < 10 then InvoiceAmount
				end, 0, 1) as Digits
			, count(*) over(partition by VendorNumber) as #Transactions
		  from [BenfordFraud].[Invoices]
	)
	select VendorNumber, Digits, count(*) as Freq
	  from f
	where #Transactions > 2 and InvoiceAmount > 0 and (VendorNumber = @VendorNumber or @VendorNumber IS NULL)
	group by VendorNumber, Digits
go

--test
SELECT * FROM [BenfordFraud].VendorInvoiceDigits (105436)
EXECUTE sp_execute_external_script
  @language = N'Python',
  @script = N'
import matplotlib as plt
print(plt.__version__)
'

drop procedure if exists [BenfordFraud].getPotentialFraudulentVendors;
go
create procedure [BenfordFraud].getPotentialFraudulentVendors (@threshold float = 0.1)
as
begin
	-- Część pierwsza projektu - rozkład benforda
	exec sp_execute_external_script
		  @language = N'Python',
		  @script = N'
import pandas as pd
import numpy as np
from scipy.stats import chisquare
import math

df_benford=InputDataSet.pivot(index="VendorNumber", columns="Digits",values="Freq")
df_benford["p"] = df_benford.apply(lambda row : chisquare(row,[i * row.sum() for i in [math.log10((d+1)/d) for d in range(1, 10)]])[1],axis = 1)
df_benford = df_benford.reset_index()
df_benford = df_benford[df_benford["p"] < threshold]
OutputDataSet = df_benford

		  ',
		  @input_data_1 = N'
	select VendorNumber, CAST(Digits AS INT) AS Digits, Freq 
	  from [BenfordFraud].VendorInvoiceDigits(default)
	order by VendorNumber asc, Digits asc;
		  ',
		  @params = N'@threshold float',
		  @threshold = @threshold
	with result sets (( VendorNumber varchar(10),
	   Digit1 int, Digit2 int, Digit3 int, Digit4 int, Digit5 int, Digit6 int, Digit7 int, Digit8 int, Digit9 int,
	   Pvalue float));
end;

exec [BenfordFraud].getPotentialFraudulentVendors 0.99

CREATE EXTERNAL LIBRARY AUC 
FROM (CONTENT = 'C:\ML\Chapter01\AUC_0.3.0.zip') 
WITH (LANGUAGE = 'R'); 
GO

go
drop procedure if exists [BenfordFraud].getVendorInvoiceDigits;
go
create procedure [BenfordFraud].getVendorInvoiceDigits (@VendorNumber varchar(10))
as
begin
	-- Część druga projektu - wykres
	exec sp_execute_external_script
		  @language = N'Python',
		  @script = N'
import matplotlib.pyplot as plt
import math
import pandas as pd
import pickle

figure, (ax1, ax2) = plt.subplots(2,1)
arguments= [1,2,3,4,5,6,7,8,9]

ax1.set_title("Frequency of occurrences of digits")
ax1.set_ylabel("Benford distribution")
ax1.plot(arguments,[math.log10((d+1)/d)*InputDataSet["Freq"].sum() for d in range(1, 10)],label = "Benford Distribution - Freq",color = "blue",marker = "x")
ax1.legend()

ax2.set_ylabel("Vendor numbers")
ax2.set_xlabel("Digits")
ax2.plot(arguments,InputDataSet.Freq,label = "Vendor numbers - Freq",color = "black",marker = "x")
ax2.legend()

final_plot = pd.DataFrame(data =[pickle.dumps(figure)])
OutputDataSet = final_plot


		  ',
		  @input_data_1 = N'select Freq from [BenfordFraud].VendorInvoiceDigits(@vendor) order by Digits;',
		  @params = N'@vendor varchar(10)',
		  @vendor = @VendorNumber
	with result sets(([chart] varbinary(max)));
end;
go

drop procedure if exists [BenfordFraud].getVendorInvoiceDigitsPlots;
go
create procedure [BenfordFraud].getVendorInvoiceDigitsPlots (@threshold float = 0.1)
as
begin
	-- Produces plots for all vendors suspected of fraud showing
	-- the distribution of invoice amount digits (Actual) vs. Benford distribution for the digit (Expected)
	create table #v ( VendorNumber varchar(10),
	   Digit1 int, Digit2 int, Digit3 int, Digit4 int, Digit5 int, Digit6 int, Digit7 int, Digit8 int, Digit9 int,
	   Pvalue float);

	insert into #v exec [BenfordFraud].getPotentialFraudulentVendors @threshold;
	truncate table [BenfordFraud].FraudulentVendorsPlots;

	declare @p cursor, @vendor varchar(10);
	set @p = cursor fast_forward for select VendorNumber from #v;
	open @p;
	while(1=1)
	begin
		fetch @p into @vendor;
		if @@fetch_status < 0 break;

		insert into [BenfordFraud].[FraudulentVendorsPlots] (Plot)
		exec [BenfordFraud].getVendorInvoiceDigits @vendor;

		update [BenfordFraud].[FraudulentVendorsPlots] set VendorNumber = @vendor where VendorNumber IS NULL;
	end;
	deallocate @p;
end;
go

exec [BenfordFraud].getVendorInvoiceDigitsPlots 

select *
from[BenfordFraud].[FraudulentVendorsPlots] 

drop procedure if exists [BenfordFraud].getPotentialFraudulentVendorsList
go
create procedure [BenfordFraud].getPotentialFraudulentVendorsList (@threshold float)
as
begin
	-- Optimized version of the proc that uses staging table for the fraud data
	select fv.*, fvp.Plot
	  from [BenfordFraud].[FraudulentVendors] as fv
	  join [BenfordFraud].[FraudulentVendorsPlots] as fvp
		on fvp.VendorNumber = fv.VendorNumber;
end;
go


exec [BenfordFraud].getPotentialFraudulentVendorsList 1